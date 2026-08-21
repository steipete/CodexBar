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
        let layout = self.settings.menuBarLayoutResolution(for: self.provider).layout
        if MenuBarPercentWindowPreference.hasPercentToken(in: layout) {
            let current = MenuBarPercentWindowPreference.current(in: layout)
            Section {
                Picker(L("menu_bar_metric_title"), selection: self.binding(layout: layout, current: current)) {
                    if current == nil {
                        // Mixed windows (e.g. Session · Weekly) are only describable in the layout
                        // editor; surface that instead of pretending one option is selected.
                        Text(L("menu_bar_layout_preset_custom"))
                            .tag(MenuBarPercentWindowPreference?.none)
                    }
                    ForEach(MenuBarPercentWindowPreference.allCases) { preference in
                        Text(preference.label).tag(MenuBarPercentWindowPreference?.some(preference))
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

    private func binding(
        layout: MenuBarLayout,
        current: MenuBarPercentWindowPreference?)
        -> Binding<MenuBarPercentWindowPreference?>
    {
        Binding(
            get: { current },
            set: { preference in
                guard let preference else { return }
                MenuBarLayoutEditorPersistence.activate(
                    preference.applied(to: layout),
                    for: self.provider,
                    settings: self.settings)
            })
    }
}
