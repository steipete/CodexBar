import AppKit
import CodexBarCore
import SwiftUI

@MainActor
struct GeneralPane: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSection(contentSpacing: 12) {
                    Text(AppStrings.tr("System"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(AppStrings.tr("Language"))
                                .font(.body)
                            Text(AppStrings.tr("Default follows system language."))
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Picker(AppStrings.tr("Language"), selection: self.$settings.appLanguage) {
                            ForEach(AppLanguage.allCases) { language in
                                Text(language.displayName).tag(language)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 200)
                    }
                    PreferenceToggleRow(
                        title: AppStrings.tr("Start at Login"),
                        subtitle: AppStrings.tr("Automatically opens CodexBar when you start your Mac."),
                        binding: self.$settings.launchAtLogin)
                }

                Divider()

                SettingsSection(contentSpacing: 12) {
                    Text(AppStrings.tr("Usage"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(isOn: self.$settings.costUsageEnabled) {
                                Text(AppStrings.tr("Show cost summary"))
                                    .font(.body)
                            }
                            .toggleStyle(.checkbox)

                            Text(AppStrings.tr("Reads local usage logs. Shows today + last 30 days cost in the menu."))
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)

                            if self.settings.costUsageEnabled {
                                Text(AppStrings.tr("Auto-refresh: hourly · Timeout: 10m"))
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)

                                self.costStatusLine(provider: .claude)
                                self.costStatusLine(provider: .codex)
                            }
                        }
                    }
                }

                Divider()

                SettingsSection(contentSpacing: 12) {
                    Text(AppStrings.tr("Automation"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(AppStrings.tr("Refresh cadence"))
                                    .font(.body)
                                Text(AppStrings.tr("How often CodexBar polls providers in the background."))
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Picker(AppStrings.tr("Refresh cadence"), selection: self.$settings.refreshFrequency) {
                                ForEach(RefreshFrequency.allCases) { option in
                                    Text(option.label).tag(option)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: 200)
                        }
                        if self.settings.refreshFrequency == .manual {
                            Text(AppStrings.tr("Auto-refresh is off; use the menu's Refresh command."))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    PreferenceToggleRow(
                        title: AppStrings.tr("Check provider status"),
                        subtitle: AppStrings.tr(
                            "Polls OpenAI/Claude status pages and Google Workspace for Gemini/Antigravity, " +
                                "surfacing incidents in the icon and menu."),
                        binding: self.$settings.statusChecksEnabled)
                    PreferenceToggleRow(
                        title: AppStrings.tr("Session quota notifications"),
                        subtitle: AppStrings.tr(
                            "Notifies when the 5-hour session quota hits 0% and when it becomes available again."),
                        binding: self.$settings.sessionQuotaNotificationsEnabled)
                }

                Divider()

                SettingsSection(contentSpacing: 12) {
                    HStack {
                        Spacer()
                        Button(AppStrings.tr("Quit CodexBar")) { NSApp.terminate(nil) }
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
            return Text(AppStrings.fmt("%@: unsupported", name))
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
            return Text(AppStrings.fmt("%@: fetching…%@", name, elapsed))
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        if let snapshot = self.store.tokenSnapshot(for: provider) {
            let updated = AppStrings.updatedString(from: snapshot.updatedAt)
            let cost = snapshot.last30DaysCostUSD.map { UsageFormatter.usdString($0) } ?? AppStrings.tr("—")
            return Text(AppStrings.fmt("%@: %@ · 30d %@", name, updated, cost))
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        if let error = self.store.tokenError(for: provider), !error.isEmpty {
            let truncated = UsageFormatter.truncatedSingleLine(error, max: 120)
            return Text(AppStrings.fmt("%@: %@", name, truncated))
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        if let lastAttempt = self.store.tokenLastAttemptAt(for: provider) {
            let when = lastAttempt.relativeDescription(now: Date(), unitsStyle: .abbreviated)
            return Text(AppStrings.fmt("%@: last attempt %@", name, when))
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        return Text(AppStrings.fmt("%@: no data yet", name))
            .font(.footnote)
            .foregroundStyle(.tertiary)
    }
}
