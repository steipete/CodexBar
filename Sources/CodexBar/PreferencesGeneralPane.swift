import AppKit
import CodexBarCore
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system = ""
    case english = "en"
    case chineseSimplified = "zh-Hans"
    case chineseTraditional = "zh-Hant"
    case japanese = "ja"
    case spanish = "es"
    case portugueseBrazilian = "pt-BR"
    case korean = "ko"
    case german = "de"
    case french = "fr"
    case arabic = "ar"
    case italian = "it"
    case vietnamese = "vi"
    case dutch = "nl"
    case turkish = "tr"
    case ukrainian = "uk"
    case indonesian = "id"
    case polish = "pl"
    case persian = "fa"
    case thai = "th"
    case galician = "gl"
    case catalan = "ca"
    case swedish = "sv"

    var id: String {
        self.rawValue
    }

    var label: String {
        switch self {
        case .system: L("language_system")
        case .english: L("language_english")
        case .chineseSimplified: L("language_chinese_simplified")
        case .chineseTraditional: L("language_chinese_traditional")
        case .japanese: L("language_japanese")
        case .spanish: L("language_spanish")
        case .portugueseBrazilian: L("language_portuguese_brazilian")
        case .korean: L("language_korean")
        case .german: L("language_german")
        case .french: L("language_french")
        case .arabic: L("language_arabic")
        case .italian: L("language_italian")
        case .vietnamese: L("language_vietnamese")
        case .dutch: L("language_dutch")
        case .turkish: L("language_turkish")
        case .ukrainian: L("language_ukrainian")
        case .indonesian: L("language_indonesian")
        case .polish: L("language_polish")
        case .persian: L("language_persian")
        case .thai: L("language_thai")
        case .galician: L("language_galician")
        case .catalan: L("language_catalan")
        case .swedish: L("language_swedish")
        }
    }
}

@MainActor
struct GeneralPane: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Picker(selection: self.$settings.appLanguage) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                } label: {
                    SettingsRowLabel(L("language_title"), subtitle: L("language_subtitle"))
                }

                Picker(selection: self.$settings.terminalApp) {
                    ForEach(TerminalApp.pickerOptions(selected: self.settings.terminalApp)) { option in
                        HStack(spacing: 6) {
                            if let icon = option.pickerIcon {
                                Image(nsImage: icon)
                            }
                            Text(option.label)
                        }
                        .tag(option)
                    }
                } label: {
                    SettingsRowLabel(L("terminal_app_title"), subtitle: L("terminal_app_subtitle"))
                }

                Toggle(L("start_at_login_title"), isOn: self.$settings.launchAtLogin)
            } header: {
                Text(L("section_system"))
            }

            Section {
                Picker(L("refresh_cadence_title"), selection: self.$settings.refreshFrequency) {
                    ForEach(RefreshFrequency.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }

                Toggle(L("refresh_on_open_title"), isOn: self.$settings.refreshAllProvidersOnMenuOpen)

                Toggle(isOn: self.$settings.statusChecksEnabled) {
                    SettingsRowLabel(
                        L("check_provider_status_title"),
                        subtitle: L("check_provider_status_subtitle"))
                }
            } header: {
                Text(L("section_automation"))
            } footer: {
                if self.settings.refreshFrequency == .manual {
                    Text(L("manual_refresh_hint"))
                }
            }

            Section {
                Toggle(isOn: self.$settings.sessionQuotaNotificationsEnabled) {
                    SettingsRowLabel(
                        L("session_quota_notifications_title"),
                        subtitle: L("session_quota_notifications_subtitle"))
                }

                Toggle(isOn: self.$settings.quotaWarningNotificationsEnabled) {
                    SettingsRowLabel(
                        L("quota_warning_notifications_title"),
                        subtitle: L("quota_warning_notifications_subtitle"))
                }

                if self.settings.quotaWarningNotificationsEnabled {
                    GlobalQuotaWarningSettingsView(settings: self.settings)
                }
            } header: {
                Text(L("section_notifications"))
            }

            Section {
                LabeledContent(L("open_menu_shortcut_title")) {
                    OpenMenuShortcutRecorder()
                }
            } header: {
                Text(L("section_keyboard_shortcut"))
            }

            Section {
                HStack {
                    Spacer()
                    Button(L("quit_app")) { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }
}
