import CodexBarCore
import SwiftUI

/// Per-provider picker for the quota window behind the menu bar percent.
///
/// Writes a per-provider layout override so the choice survives whatever the global layout says,
/// which is also how the layout editor's provider scope persists.
@MainActor
struct ProviderMenuBarPercentWindowSettingsView: View {
    let provider: UsageProvider
    @Bindable var settings: SettingsStore

    var body: some View {
        ProviderMenuBarPercentWindowPicker(
            provider: self.provider,
            iconStyle: self.settings.menuBarIconStyle,
            layout: self.layoutBinding)
    }

    var layoutBinding: Binding<MenuBarLayout> {
        Binding(
            get: { self.settings.menuBarLayoutResolution(for: self.provider).layout },
            set: { self.settings.setMenuBarLayout($0, for: self.provider) })
    }
}

@MainActor
struct ProviderMenuBarPercentWindowPicker: View {
    let provider: UsageProvider
    let iconStyle: MenuBarIconStyle
    @Binding var layout: MenuBarLayout

    var body: some View {
        let layout = self.layout
        let available = MenuBarPercentWindowPreference.available(for: self.provider, layout: layout)
        if MenuBarPercentWindowPreference.isVisible(
            iconStyle: self.iconStyle,
            layout: layout,
            available: available)
        {
            let selection = self.selectionBinding.wrappedValue
            Section {
                Picker(L("menu_bar_metric_title"), selection: self.selectionBinding) {
                    if selection == nil {
                        // Mixed windows (e.g. Session · Weekly) are only describable in the layout
                        // editor; surface that instead of pretending one option is selected.
                        Text(L("menu_bar_layout_preset_custom"))
                            .tag(MenuBarPercentWindowPreference?.none)
                    }
                    ForEach(available) { preference in
                        Text(preference.label(for: self.provider)).tag(MenuBarPercentWindowPreference?.some(preference))
                    }
                }
                .pickerStyle(.menu)
                .listRowSeparator(.hidden)
            } footer: {
                SettingsSectionFooter(L("menu_bar_metric_subtitle"))
            }
            .background(FocusResigningBackground())
        }
    }

    var selectionBinding: Binding<MenuBarPercentWindowPreference?> {
        Binding(
            get: {
                let layout = self.layout
                let available = MenuBarPercentWindowPreference.available(for: self.provider, layout: layout)
                return MenuBarPercentWindowPreference.current(in: layout)
                    .flatMap { available.contains($0) ? $0 : nil }
            },
            set: { preference in
                let layout = self.layout
                guard let preference,
                      MenuBarPercentWindowPreference.available(for: self.provider, layout: layout).contains(preference)
                else { return }
                self.layout = preference.applied(to: layout)
            })
    }
}
