import CodexBarCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings for the notch hover overlay: enablement, the provider grid, the agent-session band,
/// and the shortcut.
@MainActor
struct NotchPane: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore

    @State private var dropTargetKey: String?

    private var isEnabled: Bool {
        self.settings.notchUsageSummaryEnabled
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: self.$settings.notchUsageSummaryEnabled) {
                    SettingsRowLabel(
                        L("notch_summary_title"),
                        subtitle: L("notch_summary_caption"))
                }
            } header: {
                Text(L("section_notch_overlay"))
            } footer: {
                if NotchGeometry.hasNotchedScreen() {
                    SettingsSectionFooter(L("notch_autosize_footer"))
                } else {
                    SettingsSectionFooter(L("notch_no_display_hint"))
                }
            }

            Section {
                LabeledContent(L("notch_hotkey_title")) {
                    NotchOverlayShortcutRecorder()
                }

                Picker(selection: self.$settings.notchHotkeyMode) {
                    ForEach(NotchHotkeyMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                } label: {
                    SettingsRowLabel(L("notch_hotkey_mode_title"), subtitle: L("notch_hotkey_mode_subtitle"))
                }
                .pickerStyle(.inline)
                .disabled(!self.isEnabled)
            } header: {
                Text(L("section_notch_hotkey"))
            } footer: {
                SettingsSectionFooter(L("notch_hotkey_footer"))
            }

            Section {
                Toggle(isOn: self.$settings.notchShowsAgentSessions) {
                    SettingsRowLabel(
                        L("notch_agent_sessions_title"),
                        subtitle: L("notch_agent_sessions_subtitle"))
                }
                .disabled(!self.isEnabled || !self.settings.agentSessionsEnabled)

                Picker(selection: self.$settings.notchSessionsPlacement) {
                    ForEach(NotchSessionsPlacement.allCases, id: \.self) { placement in
                        Text(placement.label).tag(placement)
                    }
                } label: {
                    SettingsRowLabel(
                        L("notch_sessions_placement_title"),
                        subtitle: L("notch_sessions_placement_subtitle"))
                }
                .pickerStyle(.segmented)
                .disabled(!self.sessionsControlsEnabled)

                self.heightRow(
                    title: L("notch_sessions_height_title"),
                    subtitle: L("notch_sessions_height_subtitle"),
                    value: self.$settings.notchSessionsMaxHeight,
                    enabled: self.sessionsControlsEnabled)
            } header: {
                Text(L("section_notch_sessions"))
            } footer: {
                if !self.settings.agentSessionsEnabled {
                    SettingsSectionFooter(L("notch_agent_sessions_requires_menu"))
                }
            }

            Section {
                Picker(selection: self.$settings.notchColumnCount) {
                    ForEach(1...SettingsStore.notchMaxColumnCount, id: \.self) { count in
                        Text(verbatim: "\(count)").tag(count)
                    }
                } label: {
                    SettingsRowLabel(L("notch_columns_title"), subtitle: L("notch_columns_subtitle"))
                }
                .pickerStyle(.segmented)
                .disabled(!self.isEnabled)

                Toggle(isOn: self.$settings.notchMatchesRowHeights) {
                    SettingsRowLabel(
                        L("notch_match_rows_title"),
                        subtitle: L("notch_match_rows_subtitle"))
                }
                .disabled(!self.isEnabled)

                self.heightRow(
                    title: L("notch_providers_height_title"),
                    subtitle: L("notch_providers_height_subtitle"),
                    value: self.$settings.notchProvidersMaxHeight,
                    enabled: self.isEnabled)

                ForEach(self.providers) { provider in
                    self.providerRow(provider)
                }
            } header: {
                Text(L("section_notch_providers"))
            } footer: {
                SettingsSectionFooter(L("notch_items_footer"))
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .scrollContentBackground(.hidden)
        .background(FocusResigningBackground())
    }

    private var sessionsControlsEnabled: Bool {
        self.isEnabled && self.settings.agentSessionsEnabled && self.settings.notchShowsAgentSessions
    }

    private struct Provider: Identifiable {
        let instanceID: ProviderInstanceID
        let name: String

        var id: String {
            self.instanceID.rawValue
        }
    }

    /// Providers in stored order — the same order the overlay lays them out.
    private var providers: [Provider] {
        var byKey: [String: Provider] = [:]
        var keys: [String] = []

        for instanceID in self.store.enabledProvidersForDisplay() {
            guard let name = self.providerName(instanceID) else { continue }
            byKey[instanceID.rawValue] = Provider(instanceID: instanceID, name: name)
            keys.append(instanceID.rawValue)
        }

        return self.settings.notchOrderedItemKeys(keys).compactMap { byKey[$0] }
    }

    private func providerName(_ instanceID: ProviderInstanceID) -> String? {
        if let provider = instanceID.firstPartyProvider {
            return self.store.metadata(for: provider).displayName
        }
        #if canImport(JavaScriptCore)
        return UserProviderPluginRegistry.plugin(for: instanceID)?.manifest.name
        #else
        return nil
        #endif
    }

    private func heightRow(
        title: String,
        subtitle: String,
        value: Binding<Double>,
        enabled: Bool) -> some View
    {
        LabeledContent {
            HStack(spacing: 10) {
                Slider(
                    value: value,
                    in: SettingsStore.notchMinSectionHeight...SettingsStore.notchMaxSectionHeight,
                    step: 20)
                    .frame(minWidth: 160)
                Text(verbatim: "\(Int(value.wrappedValue))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
        } label: {
            SettingsRowLabel(title, subtitle: subtitle)
        }
        .disabled(!enabled)
    }

    /// A draggable row. `.onDrag`/`.onDrop` with plain text on purpose: `Transferable` needs a
    /// declared UTI to round-trip, and the payload here is just a provider's order key.
    private func providerRow(_ provider: Provider) -> some View {
        LabeledContent {
            Toggle("", isOn: self.visibilityBinding(provider.instanceID))
                .labelsHidden()
                .disabled(!self.isEnabled)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text(provider.name)
            }
        }
        .contentShape(Rectangle())
        .opacity(self.isEnabled && self.settings.isNotchProviderVisible(provider.instanceID) ? 1 : 0.45)
        .overlay(alignment: .top) {
            // The drop inserts above the targeted row, so mark that edge.
            Rectangle()
                .fill(Color.accentColor)
                .frame(height: 2)
                .opacity(self.dropTargetKey == provider.id ? 1 : 0)
        }
        .onDrag {
            NSItemProvider(object: provider.id as NSString)
        }
        .onDrop(of: [.text], isTargeted: self.dropTargetBinding(provider.id)) { providers in
            self.handleDrop(providers, before: provider.id)
        }
    }

    private func dropTargetBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { self.dropTargetKey == key },
            set: { isTargeted in
                if isTargeted {
                    self.dropTargetKey = key
                } else if self.dropTargetKey == key {
                    self.dropTargetKey = nil
                }
            })
    }

    /// The provider loads asynchronously, so the current order is captured up front and the
    /// reordered result is written back on the main actor.
    private func handleDrop(_ items: [NSItemProvider], before targetKey: String) -> Bool {
        guard let item = items.first else { return false }
        let keys = self.providers.map(\.id)
        let settings = self.settings
        self.dropTargetKey = nil
        item.loadObject(ofClass: NSString.self) { object, _ in
            guard let key = object as? String else { return }
            Task { @MainActor in
                guard let reordered = Self.reordered(keys, moving: key, before: targetKey) else { return }
                settings.setNotchItemOrder(reordered)
            }
        }
        return true
    }

    /// Moves `key` directly in front of `targetKey`; nil when the drag carried something that is
    /// not one of these rows, or landed back where it started.
    static func reordered(_ keys: [String], moving key: String, before targetKey: String) -> [String]? {
        guard key != targetKey, let from = keys.firstIndex(of: key) else { return nil }
        var keys = keys
        keys.remove(at: from)
        guard let to = keys.firstIndex(of: targetKey) else { return nil }
        keys.insert(key, at: to)
        return keys
    }

    private func visibilityBinding(_ instanceID: ProviderInstanceID) -> Binding<Bool> {
        Binding(
            get: { self.settings.isNotchProviderVisible(instanceID) },
            set: { self.settings.setNotchProviderVisible(instanceID, visible: $0) })
    }
}
