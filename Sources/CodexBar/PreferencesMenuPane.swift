import CodexBarCore
import SwiftUI

@MainActor
struct MenuPane: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore

    var body: some View {
        Form {
            Section {
                SettingsMenuPicker(
                    selection: self.$settings.usageBarsFillOption,
                    options: MenuSettingsMenuOptions.usageBarsFill,
                    label: { Text(L("usage_bars_fill_title")) },
                    optionLabel: { option in
                        Text(option.label)
                    })

                Toggle(isOn: self.$settings.quotaWarningMarkersVisible) {
                    SettingsRowLabel(
                        L("show_quota_warning_markers_title"),
                        subtitle: L("show_quota_warning_markers_subtitle"))
                }

                SettingsMenuPicker(
                    selection: self.$settings.weeklyProgressWorkDays,
                    options: MenuSettingsMenuOptions.weeklyProgressWorkDays,
                    label: {
                        Text(L("weekly_progress_work_days_title"))
                    },
                    optionLabel: { workDays in
                        Text(MenuSettingsMenuOptions.weeklyProgressWorkDaysLabel(workDays))
                    })

                SettingsMenuPicker(
                    selection: self.$settings.resetTimesOption,
                    options: MenuSettingsMenuOptions.resetTimes,
                    label: { Text(L("reset_times_title")) },
                    optionLabel: { option in
                        Text(option.label)
                    })
            } header: {
                Text(L("section_usage"))
            }

            Section {
                Toggle(L("show_provider_changelog_links_title"), isOn: self.$settings.providerChangelogLinksEnabled)

                Toggle(isOn: self.$settings.showOptionalCreditsAndExtraUsage) {
                    SettingsRowLabel(
                        L("show_credits_extra_usage_title"),
                        subtitle: L("show_credits_extra_usage_subtitle"))
                }

                SettingsMenuPicker(
                    selection: self.$settings.multiAccountMenuLayout,
                    options: MenuSettingsMenuOptions.multiAccountLayouts,
                    label: {
                        Text(L("multi_account_layout_title"))
                    },
                    optionLabel: { layout in
                        Text(layout.label)
                    })
            } header: {
                Text(L("section_content"))
            }

            CostSummarySettingsSection(settings: self.settings, store: self.store)

            Section {
                Toggle(isOn: self.$settings.agentSessionsEnabled) {
                    SettingsRowLabel(
                        L("agent_sessions_title"),
                        subtitle: L("agent_sessions_subtitle"))
                }

                SettingsMenuPicker(
                    selection: self.$settings.agentSessionLabelStyle,
                    options: MenuSettingsMenuOptions.agentSessionLabelStyles,
                    label: {
                        SettingsRowLabel(
                            L("agent_session_labels_title"),
                            subtitle: L("agent_session_labels_subtitle"))
                    },
                    optionLabel: { style in
                        Text(style.label)
                    })
                    .disabled(!self.settings.agentSessionsEnabled)

                TextField(L("agent_sessions_hosts_title"), text: self.$settings.agentSessionsManualHosts)
                    .disabled(!self.settings.agentSessionsEnabled)
            } header: {
                Text(L("section_agent_sessions"))
            } footer: {
                SettingsSectionFooter(L("agent_sessions_footer"))
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .scrollContentBackground(.hidden)
        .background(FocusResigningBackground())
    }
}

/// Cost summary settings grouped-form section, including per-provider fetch status in the footer.
@MainActor
struct CostSummarySettingsSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore

    var body: some View {
        Section {
            SettingsMenuPicker(
                selection: self.$settings.costSummaryOption,
                options: MenuSettingsMenuOptions.costSummaries,
                label: {
                    SettingsRowLabel(L("cost_summary_title"), subtitle: L("show_cost_summary_subtitle"))
                },
                optionLabel: { option in
                    Text(option.label)
                })

            if self.settings.costUsageEnabled {
                CostHistoryDaysEditor(settings: self.settings)

                Toggle(isOn: self.$settings.costComparisonPeriodsEnabled) {
                    SettingsRowLabel(
                        L("cost_comparison_periods_title"),
                        subtitle: L("cost_comparison_periods_subtitle"))
                }
            }
        } header: {
            Text(L("section_cost_summary"))
        } footer: {
            if self.settings.costUsageEnabled {
                SettingsSectionFooter {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("cost_auto_refresh_info"))
                        self.costStatusLine(provider: .claude)
                        self.costStatusLine(provider: .codex)
                        self.costStatusLine(provider: .cursor)
                        Text(Self.costDataExplanation())
                    }
                }
            }
        }
    }

    static func costDataExplanation() -> String {
        L("cost_data_explanation")
    }

    private func costStatusLine(provider: UsageProvider) -> Text {
        let name = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName

        guard ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.supportsTokenCost else {
            return Text(String(format: L("cost_status_unsupported"), name))
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
        }
        if let snapshot = self.store.tokenSnapshot(for: provider) {
            let updated = UsageFormatter.updatedString(from: snapshot.updatedAt)
            let cost = snapshot.last30DaysCostUSD
                .map { UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode) } ?? "—"
            let window = snapshot.historyLabel ?? (snapshot.historyDays == 1 ? "today" : "\(snapshot.historyDays)d")
            return Text(String(format: L("cost_status_snapshot"), name, updated, window, cost))
        }
        if let error = self.store.tokenError(for: provider), !error.isEmpty {
            let truncated = UsageFormatter.truncatedSingleLine(error, max: 120)
            return Text(String(format: L("cost_status_error"), name, truncated))
        }
        if let lastAttempt = self.store.tokenLastAttemptAt(for: provider) {
            let rel = RelativeDateTimeFormatter()
            rel.locale = Locale(identifier: "en_US")
            rel.unitsStyle = .abbreviated
            let when = rel.localizedString(for: lastAttempt, relativeTo: Date())
            return Text(String(format: L("cost_status_last_attempt"), name, when))
        }
        return Text(String(format: L("cost_status_no_data"), name))
    }
}

@MainActor
struct CostHistoryDaysEditor: View {
    @Bindable var settings: SettingsStore

    static func title(days: Int) -> String {
        String(format: L("cost_history_days_title"), days)
    }

    var body: some View {
        LabeledContent(Self.title(days: self.settings.costUsageHistoryDays)) {
            HStack(spacing: 8) {
                TextField(
                    Self.title(days: self.settings.costUsageHistoryDays),
                    value: self.$settings.costUsageHistoryDays,
                    format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 64)

                Stepper(value: self.$settings.costUsageHistoryDays, in: 1...365, step: 1) {
                    EmptyView()
                }
                .labelsHidden()
            }
        }
    }
}
