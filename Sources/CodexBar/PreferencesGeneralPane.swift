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
    case russian = "ru"
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
        L(self.labelKey, language: self.labelLanguage)
    }

    private var labelLanguage: String {
        switch self {
        case .system, .english:
            "en"
        default:
            self.rawValue
        }
    }

    private var labelKey: String {
        switch self {
        case .system: "language_system"
        case .english: "language_english"
        case .chineseSimplified: "language_chinese_simplified"
        case .chineseTraditional: "language_chinese_traditional"
        case .japanese: "language_japanese"
        case .spanish: "language_spanish"
        case .portugueseBrazilian: "language_portuguese_brazilian"
        case .korean: "language_korean"
        case .german: "language_german"
        case .french: "language_french"
        case .arabic: "language_arabic"
        case .italian: "language_italian"
        case .vietnamese: "language_vietnamese"
        case .dutch: "language_dutch"
        case .turkish: "language_turkish"
        case .ukrainian: "language_ukrainian"
        case .russian: "language_russian"
        case .indonesian: "language_indonesian"
        case .polish: "language_polish"
        case .persian: "language_persian"
        case .thai: "language_thai"
        case .galician: "language_galician"
        case .catalan: "language_catalan"
        case .swedish: "language_swedish"
        }
    }
}

@MainActor
struct GeneralPane: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                SettingsMenuPicker(
                    selection: self.$settings.appLanguage,
                    options: GeneralSettingsMenuOptions.languages,
                    label: {
                        SettingsRowLabel(L("language_title"), subtitle: L("language_subtitle"))
                    },
                    optionLabel: { rawValue in
                        Text(verbatim: AppLanguage(rawValue: rawValue)?.label ?? rawValue)
                    })

                SettingsMenuPicker(
                    selection: self.$settings.terminalApp,
                    options: GeneralSettingsMenuOptions.terminalApps(selected: self.settings.terminalApp),
                    label: {
                        SettingsRowLabel(L("terminal_app_title"), subtitle: L("terminal_app_subtitle"))
                    },
                    optionLabel: { option in
                        HStack(spacing: 6) {
                            if let icon = option.pickerIcon {
                                Image(nsImage: icon)
                            }
                            Text(option.label)
                        }
                    })

                Toggle(L("start_at_login_title"), isOn: self.$settings.launchAtLogin)
            } header: {
                Text(L("section_system"))
            }

            Section {
                SettingsMenuPicker(
                    selection: self.$settings.refreshFrequency,
                    options: GeneralSettingsMenuOptions.refreshFrequencies,
                    label: { Text(L("refresh_cadence_title")) },
                    optionLabel: { option in Text(option.label) })

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
        .scrollContentBackground(.hidden)
    }
}
