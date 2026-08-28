import SwiftUI

@MainActor
struct NotificationsPane: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle(isOn: self.$settings.sessionQuotaNotificationsEnabled) {
                    SettingsRowLabel(
                        L("quota_depleted_title"),
                        subtitle: L("session_quota_notifications_subtitle"))
                }

                Toggle(isOn: self.$settings.quotaWarningNotificationsEnabled) {
                    SettingsRowLabel(
                        L("threshold_warnings_title"),
                        subtitle: L("quota_warning_notifications_subtitle"))
                }

                Toggle(isOn: self.$settings.predictivePaceWarningNotificationsEnabled) {
                    SettingsRowLabel(
                        L("predictive_pace_warnings_title"),
                        subtitle: L("predictive_pace_warnings_subtitle"))
                }

                let warningSettingsVisibility = QuotaWarningSettingsVisibility(
                    thresholdWarningsEnabled: self.settings.quotaWarningNotificationsEnabled,
                    predictiveWarningsEnabled: self.settings.predictivePaceWarningNotificationsEnabled)
                if warningSettingsVisibility.showsDeliveryControls {
                    GlobalQuotaWarningSettingsView(
                        settings: self.settings,
                        showsThresholdControls: warningSettingsVisibility.showsThresholdControls)
                }
            } header: {
                Text(L("section_alerts"))
            }

            Section {
                SettingsMenuPicker(
                    selection: self.$settings.confettiCelebrationOption,
                    options: NotificationsSettingsMenuOptions.confettiCelebrations,
                    label: {
                        SettingsRowLabel(
                            L("confetti_on_reset_title"),
                            subtitle: L("confetti_on_reset_subtitle"))
                    },
                    optionLabel: { option in
                        Text(option.label)
                    })
            } header: {
                Text(L("section_celebrations"))
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .scrollContentBackground(.hidden)
        .background(FocusResigningBackground())
    }
}
