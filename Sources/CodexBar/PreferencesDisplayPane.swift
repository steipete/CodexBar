import CodexBarCore
import SwiftUI

@MainActor
struct DisplayPane: View {
    private static let maxOverviewProviders = SettingsStore.mergedOverviewProviderLimit

    static func overviewProviderLimitText(limit: Int = Self.maxOverviewProviders) -> String {
        L("overview_choose_providers", String(limit))
    }

    @State private var isOverviewProviderPopoverPresented = false
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore

    var body: some View {
        Form {
            Section {
                Toggle(isOn: self.$settings.mergeIcons) {
                    SettingsRowLabel(L("merge_icons_title"), subtitle: L("merge_icons_subtitle"))
                }

                Toggle(L("switcher_shows_icons_title"), isOn: self.$settings.switcherShowsIcons)
                    .disabled(!self.settings.mergeIcons)

                Toggle(isOn: self.$settings.menuBarShowsHighestUsage) {
                    SettingsRowLabel(
                        L("show_most_used_provider_title"),
                        subtitle: L("show_most_used_provider_subtitle"))
                }
                .disabled(!self.settings.mergeIcons)

                self.overviewProviderRow
                    .disabled(!self.settings.mergeIcons)

                Toggle(L("hide_critters_title"), isOn: self.$settings.menuBarHidesCritters)

                Toggle(isOn: self.$settings.menuBarShowsBrandIconWithPercent) {
                    SettingsRowLabel(
                        L("menu_bar_shows_percent_title"),
                        subtitle: L("menu_bar_shows_percent_subtitle"))
                }

                Picker(L("display_mode_title"), selection: self.$settings.menuBarDisplayMode) {
                    ForEach(MenuBarDisplayMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .disabled(!self.settings.menuBarShowsBrandIconWithPercent)
            } header: {
                Text(L("section_menu_bar"))
            }

            Section {
                Toggle(L("show_usage_as_used_title"), isOn: self.$settings.usageBarsShowUsed)

                Toggle(isOn: self.$settings.quotaWarningMarkersVisible) {
                    SettingsRowLabel(
                        L("show_quota_warning_markers_title"),
                        subtitle: L("show_quota_warning_markers_subtitle"))
                }

                Picker(L("weekly_progress_work_days_title"), selection: self.$settings.weeklyProgressWorkDays) {
                    Text(L("Off")).tag(nil as Int?)
                    Text(L("4 days")).tag(4 as Int?)
                    Text(L("5 days")).tag(5 as Int?)
                    Text(L("7 days")).tag(7 as Int?)
                }

                Toggle(L("show_reset_time_as_clock_title"), isOn: self.$settings.resetTimesShowAbsolute)

                Toggle(L("show_provider_changelog_links_title"), isOn: self.$settings.providerChangelogLinksEnabled)

                Toggle(isOn: self.$settings.showOptionalCreditsAndExtraUsage) {
                    SettingsRowLabel(
                        L("show_credits_extra_usage_title"),
                        subtitle: L("show_credits_extra_usage_subtitle"))
                }

                Picker(L("multi_account_layout_title"), selection: self.$settings.multiAccountMenuLayout) {
                    ForEach(MultiAccountMenuLayout.allCases) { layout in
                        Text(layout.label).tag(layout)
                    }
                }
            } header: {
                Text(L("section_menu_content"))
            }

            CostSummarySettingsSection(settings: self.settings, store: self.store)

            Section {
                Toggle(isOn: self.$settings.randomBlinkEnabled) {
                    SettingsRowLabel(L("surprise_me_title"), subtitle: L("surprise_me_subtitle"))
                }

                Toggle(L("session_limit_confetti_title"), isOn: self.$settings.confettiOnSessionLimitResetsEnabled)

                Toggle(L("weekly_limit_confetti_title"), isOn: self.$settings.confettiOnWeeklyLimitResetsEnabled)
            } header: {
                Text(L("section_loading_animations"))
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .scrollContentBackground(.hidden)
        .onAppear {
            self.reconcileOverviewSelection()
        }
        .onChange(of: self.settings.mergeIcons) { _, isEnabled in
            guard isEnabled else {
                self.isOverviewProviderPopoverPresented = false
                return
            }
            self.reconcileOverviewSelection()
        }
        .onChange(of: self.activeProvidersInOrder) { _, _ in
            if self.activeProvidersInOrder.isEmpty {
                self.isOverviewProviderPopoverPresented = false
            }
            self.reconcileOverviewSelection()
        }
    }

    private var overviewProviderRow: some View {
        LabeledContent {
            if self.showsOverviewConfigureButton {
                Button(L("configure")) {
                    self.isOverviewProviderPopoverPresented = true
                }
                .popover(isPresented: self.$isOverviewProviderPopoverPresented, arrowEdge: .bottom) {
                    self.overviewProviderPopover
                }
            }
        } label: {
            SettingsRowLabel(L("overview_tab_providers_title"), subtitle: self.overviewProviderSubtitle)
        }
    }

    private var overviewProviderSubtitle: String {
        if !self.settings.mergeIcons {
            L("overview_enable_merge_icons_hint")
        } else if self.activeProvidersInOrder.isEmpty {
            L("overview_no_providers_hint")
        } else {
            self.overviewProviderSelectionSummary
        }
    }

    private var overviewProviderPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Self.overviewProviderLimitText())
                .font(.headline)
            Text(L("overview_rows_follow_order"))
                .font(.footnote)
                .foregroundStyle(.tertiary)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(self.activeProvidersInOrder, id: \.self) { provider in
                        Toggle(
                            isOn: Binding(
                                get: { self.overviewSelectedProviders.contains(provider) },
                                set: { shouldSelect in
                                    self.setOverviewProviderSelection(provider: provider, isSelected: shouldSelect)
                                })) {
                            Text(self.providerDisplayName(provider))
                                .font(.body)
                        }
                        .toggleStyle(.checkbox)
                        .disabled(
                            !self.overviewSelectedProviders.contains(provider) &&
                                self.overviewSelectedProviders.count >= Self.maxOverviewProviders)
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(12)
        .frame(width: 280)
    }

    private var activeProvidersInOrder: [UsageProvider] {
        self.store.enabledProviders()
    }

    private var overviewSelectedProviders: [UsageProvider] {
        self.settings.resolvedMergedOverviewProviders(
            activeProviders: self.activeProvidersInOrder,
            maxVisibleProviders: Self.maxOverviewProviders)
    }

    private var showsOverviewConfigureButton: Bool {
        self.settings.mergeIcons && !self.activeProvidersInOrder.isEmpty
    }

    private var overviewProviderSelectionSummary: String {
        let selectedNames = self.overviewSelectedProviders.map(self.providerDisplayName)
        guard !selectedNames.isEmpty else { return L("overview_no_providers_selected") }
        return selectedNames.joined(separator: ", ")
    }

    private func providerDisplayName(_ provider: UsageProvider) -> String {
        ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
    }

    private func setOverviewProviderSelection(provider: UsageProvider, isSelected: Bool) {
        _ = self.settings.setMergedOverviewProviderSelection(
            provider: provider,
            isSelected: isSelected,
            activeProviders: self.activeProvidersInOrder,
            maxVisibleProviders: Self.maxOverviewProviders)
    }

    private func reconcileOverviewSelection() {
        _ = self.settings.reconcileMergedOverviewSelectedProviders(
            activeProviders: self.activeProvidersInOrder,
            maxVisibleProviders: Self.maxOverviewProviders)
    }
}

/// Cost summary settings grouped-form section, including per-provider fetch status in the footer.
@MainActor
struct CostSummarySettingsSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore

    var body: some View {
        Section {
            Toggle(isOn: self.$settings.costUsageEnabled) {
                SettingsRowLabel(L("show_cost_summary"), subtitle: L("show_cost_summary_subtitle"))
            }

            if self.settings.costUsageEnabled {
                Picker(selection: self.$settings.costSummaryDisplayStyle) {
                    ForEach(CostSummaryDisplayStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                } label: {
                    SettingsRowLabel(
                        L("cost_summary_style_title"),
                        subtitle: self.settings.costSummaryDisplayStyle.helpText)
                }

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
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("cost_auto_refresh_info"))
                    self.costStatusLine(provider: .claude)
                    self.costStatusLine(provider: .codex)
                }
            }
        }
    }

    private func costStatusLine(provider: UsageProvider) -> Text {
        let name = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName

        guard provider == .claude || provider == .codex else {
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
