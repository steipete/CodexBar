import CodexBarCore
import SwiftUI

/// Per-provider picker for the quota window behind the menu bar percent.
///
/// Writes a per-provider layout override so the choice survives whatever the global layout says,
/// which is also how the layout editor's provider scope persists.
@MainActor
struct ProviderMenuBarPercentWindowSettingsView: View {
    let instanceID: ProviderInstanceID
    @Bindable var settings: SettingsStore
    var snapshot: UsageSnapshot?

    init(provider: UsageProvider, settings: SettingsStore, snapshot: UsageSnapshot? = nil) {
        self.init(instanceID: provider.instanceID, settings: settings, snapshot: snapshot)
    }

    init(instanceID: ProviderInstanceID, settings: SettingsStore, snapshot: UsageSnapshot? = nil) {
        self.instanceID = instanceID
        self.settings = settings
        self.snapshot = snapshot
    }

    var body: some View {
        ProviderMenuBarPercentWindowPicker(
            provider: self.instanceID.firstPartyProvider,
            iconStyle: self.settings.menuBarIconStyle,
            layout: self.layoutBinding,
            metric: self.metricBinding,
            snapshot: self.snapshot)
    }

    var layoutBinding: Binding<MenuBarLayout> {
        Binding(
            get: {
                if let provider = self.instanceID.firstPartyProvider {
                    return self.settings.menuBarLayoutResolution(for: provider).layout
                }
                return self.settings.menuBarLayout(forPlugin: self.instanceID)
            },
            set: { self.settings.setMenuBarLayout($0, forInstanceID: self.instanceID) })
    }

    var metricBinding: Binding<MenuBarMetricPreference> {
        guard let provider = self.instanceID.firstPartyProvider else { return .constant(.automatic) }
        return Binding(
            get: { self.settings.menuBarMetricPreference(for: provider) },
            set: { self.settings.setMenuBarMetricPreference($0, for: provider) })
    }
}

@MainActor
struct ProviderMenuBarPercentWindowPicker: View {
    let provider: UsageProvider?
    let iconStyle: MenuBarIconStyle
    @Binding var layout: MenuBarLayout
    var metric: Binding<MenuBarMetricPreference> = .constant(.automatic)
    var snapshot: UsageSnapshot?

    var available: [MenuBarPercentWindowPreference] {
        if let provider {
            return MenuBarPercentWindowPreference.available(for: provider, layout: self.layout)
        }
        return MenuBarPercentWindowPreference.availableForPlugin(snapshot: self.snapshot, layout: self.layout)
    }

    var body: some View {
        if self.provider == nil {
            // Plugin settings already own the section; the choice also controls the switcher in meter mode.
            self.picker
        } else if MenuBarPercentWindowPreference.isVisible(
            iconStyle: self.iconStyle,
            layout: self.layout,
            available: self.available)
        {
            Section {
                self.picker
            } footer: {
                SettingsSectionFooter(L("menu_bar_metric_subtitle"))
            }
            .background(FocusResigningBackground())
        }
    }

    private var picker: some View {
        Picker(L("menu_bar_metric_title"), selection: self.selectionBinding) {
            if self.selectionBinding.wrappedValue == nil {
                // Mixed windows stay under the layout editor's control.
                Text(L("menu_bar_layout_preset_custom"))
                    .tag(MenuBarPercentWindowPreference?.none)
            }
            ForEach(self.available) { preference in
                Text(preference.label(for: self.provider, snapshot: self.snapshot))
                    .tag(MenuBarPercentWindowPreference?.some(preference))
            }
        }
        .pickerStyle(.menu)
        .listRowSeparator(.hidden)
    }

    var selectionBinding: Binding<MenuBarPercentWindowPreference?> {
        Binding(
            get: {
                let metric = self.available.contains(.monthlyPlan) ? self.metric.wrappedValue : nil
                return MenuBarPercentWindowPreference.current(in: self.layout, metric: metric)
                    .flatMap { self.available.contains($0) ? $0 : nil }
            },
            set: { preference in
                let layout = self.layout
                guard let preference, self.available.contains(preference) else { return }
                let updated = preference.applied(to: layout)
                if let provider = self.provider,
                   MenuBarPercentWindowPreference.available(for: provider).contains(.monthlyPlan)
                {
                    self.metric.wrappedValue = preference.menuBarMetric
                    // Without a percentage to change, only the metric is stored, so the layout keeps following
                    // its source instead of becoming a provider override.
                    guard MenuBarPercentWindowPreference.hasPercentToken(in: layout) else { return }
                }
                self.layout = updated
            })
    }
}
