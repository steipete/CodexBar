import CodexBarCore
import SwiftUI

@MainActor
struct DisplayPane: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSection(contentSpacing: 12) {
                    Text(L10n.tr("settings.display.menu_bar.section", fallback: "Menu bar"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    PreferenceToggleRow(
                        title: L10n.tr("settings.display.menu_bar.merge_icons.title", fallback: "Merge Icons"),
                        subtitle: L10n.tr(
                            "settings.display.menu_bar.merge_icons.subtitle",
                            fallback: "Use a single menu bar icon with a provider switcher."),
                        binding: self.$settings.mergeIcons)
                    PreferenceToggleRow(
                        title: L10n.tr(
                            "settings.display.menu_bar.switcher_icons.title",
                            fallback: "Switcher shows icons"),
                        subtitle: L10n.tr(
                            "settings.display.menu_bar.switcher_icons.subtitle",
                            fallback: "Show provider icons in the switcher (otherwise show a weekly progress line)."),
                        binding: self.$settings.switcherShowsIcons)
                        .disabled(!self.settings.mergeIcons)
                        .opacity(self.settings.mergeIcons ? 1 : 0.5)
                    PreferenceToggleRow(
                        title: L10n.tr(
                            "settings.display.menu_bar.highest_usage.title",
                            fallback: "Show most-used provider"),
                        subtitle: L10n.tr(
                            "settings.display.menu_bar.highest_usage.subtitle",
                            fallback: "Menu bar auto-shows the provider closest to its rate limit."),
                        binding: self.$settings.menuBarShowsHighestUsage)
                        .disabled(!self.settings.mergeIcons)
                        .opacity(self.settings.mergeIcons ? 1 : 0.5)
                    PreferenceToggleRow(
                        title: L10n.tr(
                            "settings.display.menu_bar.brand_percent.title",
                            fallback: "Menu bar shows percent"),
                        subtitle: L10n.tr(
                            "settings.display.menu_bar.brand_percent.subtitle",
                            fallback: "Replace critter bars with provider branding icons and a percentage."),
                        binding: self.$settings.menuBarShowsBrandIconWithPercent)
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.tr("settings.display.menu_bar.mode.title", fallback: "Display mode"))
                                .font(.body)
                            Text(L10n.tr(
                                "settings.display.menu_bar.mode.subtitle",
                                fallback: "Choose what to show in the menu bar (Pace shows usage vs. expected)."))
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Picker(
                            L10n.tr("settings.display.menu_bar.mode.title", fallback: "Display mode"),
                            selection: self.$settings.menuBarDisplayMode)
                        {
                            ForEach(MenuBarDisplayMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 200)
                    }
                    .disabled(!self.settings.menuBarShowsBrandIconWithPercent)
                    .opacity(self.settings.menuBarShowsBrandIconWithPercent ? 1 : 0.5)
                }

                Divider()

                SettingsSection(contentSpacing: 12) {
                    Text(L10n.tr("settings.display.menu_content.section", fallback: "Menu content"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    PreferenceToggleRow(
                        title: L10n.tr(
                            "settings.display.menu_content.usage_as_used.title",
                            fallback: "Show usage as used"),
                        subtitle: L10n.tr(
                            "settings.display.menu_content.usage_as_used.subtitle",
                            fallback: "Progress bars fill as you consume quota (instead of showing remaining)."),
                        binding: self.$settings.usageBarsShowUsed)
                    PreferenceToggleRow(
                        title: L10n.tr(
                            "settings.display.menu_content.reset_clock.title",
                            fallback: "Show reset time as clock"),
                        subtitle: L10n.tr(
                            "settings.display.menu_content.reset_clock.subtitle",
                            fallback: "Display reset times as absolute clock values instead of countdowns."),
                        binding: self.$settings.resetTimesShowAbsolute)
                    PreferenceToggleRow(
                        title: L10n.tr(
                            "settings.display.menu_content.optional_usage.title",
                            fallback: "Show credits + extra usage"),
                        subtitle: L10n.tr(
                            "settings.display.menu_content.optional_usage.subtitle",
                            fallback: "Show Codex Credits and Claude Extra usage sections in the menu."),
                        binding: self.$settings.showOptionalCreditsAndExtraUsage)
                    PreferenceToggleRow(
                        title: L10n.tr(
                            "settings.display.menu_content.all_token_accounts.title",
                            fallback: "Show all token accounts"),
                        subtitle: L10n.tr(
                            "settings.display.menu_content.all_token_accounts.subtitle",
                            fallback: "Stack token accounts in the menu (otherwise show an account switcher bar)."),
                        binding: self.$settings.showAllTokenAccountsInMenu)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }
}
