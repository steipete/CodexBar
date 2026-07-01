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
        case .catalan: L("language_catalan")
        case .swedish: L("language_swedish")
        }
    }
}

@MainActor
struct GeneralPane: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSection(contentSpacing: 12) {
                    Text(L("section_system"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L("language_title"))
                                    .font(.body)
                                Text(L("language_subtitle"))
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Picker(L("language_title"), selection: self.$settings.appLanguage) {
                                ForEach(AppLanguage.allCases) { option in
                                    Text(option.label).tag(option.rawValue)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: 200)
                        }
                    }

                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("terminal_app_title"))
                                .font(.body)
                            Text(L("terminal_app_subtitle"))
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Picker(L("terminal_app_title"), selection: self.$settings.terminalApp) {
                            ForEach(TerminalApp.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 200)
                    }

                    PreferenceToggleRow(
                        title: L("start_at_login_title"),
                        subtitle: L("start_at_login_subtitle"),
                        binding: self.$settings.launchAtLogin)
                }

                Divider()

                SettingsSection(contentSpacing: 12) {
                    Text(L("section_usage"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(isOn: self.$settings.costUsageEnabled) {
                                Text(L("show_cost_summary"))
                                    .font(.body)
                            }
                            .toggleStyle(.checkbox)

                            Text(L("show_cost_summary_subtitle"))
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)

                            if self.settings.costUsageEnabled {
                                VStack(alignment: .leading, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(alignment: .center, spacing: 12) {
                                            Text(L("cost_summary_style_title"))
                                                .font(.body)
                                            Spacer(minLength: 16)
                                            Picker(
                                                L("cost_summary_style_title"),
                                                selection: self.$settings.costSummaryDisplayStyle)
                                            {
                                                ForEach(CostSummaryDisplayStyle.allCases) { style in
                                                    Text(style.label).tag(style)
                                                }
                                            }
                                            .labelsHidden()
                                            .pickerStyle(.menu)
                                            .frame(width: CostSummarySettingsLayout.controlWidth)
                                        }

                                        Text(self.settings.costSummaryDisplayStyle.helpText)
                                            .font(.footnote)
                                            .foregroundStyle(.tertiary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(.top, 4)

                                    CostHistoryDaysEditor(settings: self.settings)

                                    Text(L("cost_auto_refresh_info"))
                                        .font(.footnote)
                                        .foregroundStyle(.tertiary)

                                    self.costStatusLine(provider: .claude)
                                    self.costStatusLine(provider: .codex)
                                }
                                .padding(.leading, 20)
                            }
                        }
                    }
                }

                Divider()

                SettingsSection(contentSpacing: 12) {
                    Text(L("section_automation"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L("refresh_cadence_title"))
                                    .font(.body)
                                Text(L("refresh_cadence_subtitle"))
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Picker(L("Refresh cadence"), selection: self.$settings.refreshFrequency) {
                                ForEach(RefreshFrequency.allCases) { option in
                                    Text(option.label).tag(option)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: 200)
                        }
                        if self.settings.refreshFrequency == .manual {
                            Text(L("manual_refresh_hint"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    PreferenceToggleRow(
                        title: L("check_provider_status_title"),
                        subtitle: L("check_provider_status_subtitle"),
                        binding: self.$settings.statusChecksEnabled)
                    PreferenceToggleRow(
                        title: L("session_quota_notifications_title"),
                        subtitle: L("session_quota_notifications_subtitle"),
                        binding: self.$settings.sessionQuotaNotificationsEnabled)
                    PreferenceToggleRow(
                        title: L("quota_warning_notifications_title"),
                        subtitle: L("quota_warning_notifications_subtitle"),
                        binding: self.$settings.quotaWarningNotificationsEnabled)
                    if self.settings.quotaWarningNotificationsEnabled {
                        GlobalQuotaWarningSettingsView(settings: self.settings)
                    }
                }

                Divider()

                SettingsSection(contentSpacing: 12) {
                    HStack {
                        Spacer()
                        Button(L("quit_app")) { NSApp.terminate(nil) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private func costStatusLine(provider: UsageProvider) -> some View {
        let name = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName

        guard provider == .claude || provider == .codex else {
            return Text(String(format: L("cost_status_unsupported"), name))
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }

        if self.store.isTokenRefreshInFlight(for: provider) {
            let elapsed: String = {
                guard let startedAt = self.store.tokenLastAttemptAt(for: provider) else { return "" }
                let seconds = max(0, Date().timeIntervalSince(startedAt))
                let formatter = DateComponentsFormatter()
                formatter.allowedUnits = seconds < 60 ? [.second] : [.minute, .second]
                formatter.unitsStyle = .abbreviated
                return formatter.string(from: seconds).map { " (\($0))" } ?? ""
            }()
            return Text(String(format: L("cost_status_fetching"), name, elapsed))
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        if let snapshot = self.store.tokenSnapshot(for: provider) {
            let updated = UsageFormatter.updatedString(from: snapshot.updatedAt)
            let cost = snapshot.last30DaysCostUSD
                .map { UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode) } ?? "—"
            let window = snapshot.historyLabel ?? (snapshot.historyDays == 1 ? "today" : "\(snapshot.historyDays)d")
            return Text(String(format: L("cost_status_snapshot"), name, updated, window, cost))
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        if let error = self.store.tokenError(for: provider), !error.isEmpty {
            let truncated = UsageFormatter.truncatedSingleLine(error, max: 120)
            return Text(String(format: L("cost_status_error"), name, truncated))
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        if let lastAttempt = self.store.tokenLastAttemptAt(for: provider) {
            let rel = RelativeDateTimeFormatter()
            rel.locale = Locale(identifier: "en_US")
            rel.unitsStyle = .abbreviated
            let when = rel.localizedString(for: lastAttempt, relativeTo: Date())
            return Text(String(format: L("cost_status_last_attempt"), name, when))
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        return Text(String(format: L("cost_status_no_data"), name))
            .font(.footnote)
            .foregroundStyle(.tertiary)
    }
}

private enum CostSummarySettingsLayout {
    static let controlWidth: CGFloat = 210
}

@MainActor
struct CostHistoryDaysEditor: View {
    @Bindable var settings: SettingsStore

    static func title(days: Int) -> String {
        String(format: L("cost_history_days_title"), days)
    }

    var body: some View {
        let title = Self.title(days: self.settings.costUsageHistoryDays)

        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Stepper(
                value: self.$settings.costUsageHistoryDays,
                in: 1...365,
                step: 1)
            {
                Text(title)
                    .font(.footnote)
            }

            TextField(
                title,
                value: self.$settings.costUsageHistoryDays,
                format: .number)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.footnote)
                .monospacedDigit()
                .frame(width: 64)
        }
    }
}
