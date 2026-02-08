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
                    Text(L10n.tr("settings.general.system.section", fallback: "System"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    PreferenceToggleRow(
                        title: L10n.tr("settings.general.system.start_at_login.title", fallback: "Start at Login"),
                        subtitle: L10n.tr(
                            "settings.general.system.start_at_login.subtitle",
                            fallback: "Automatically opens CodexBar when you start your Mac."),
                        binding: self.$settings.launchAtLogin)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.tr("settings.general.language.title", fallback: "Language"))
                                    .font(.body)
                                Text(L10n.tr(
                                    "settings.general.language.subtitle",
                                    fallback: "Choose app display language."))
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Picker("", selection: self.$settings.appLanguage) {
                                ForEach(AppLanguageOption.allCases) { option in
                                    Text(option.label).tag(option)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: 200)
                        }
                        Text(L10n.tr(
                            "settings.general.language.restart_hint",
                            fallback: "Language changes apply after restart."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        HStack {
                            Spacer()
                            Button(L10n.tr("settings.general.language.apply_restart", fallback: "Apply & Restart")) {
                                self.restartApp()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                Divider()

                SettingsSection(contentSpacing: 12) {
                    Text(L10n.tr("settings.general.cliproxy.section", fallback: "CLIProxyAPI"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.tr("settings.general.cliproxy.url.title", fallback: "Base URL"))
                                .font(.body)
                            Text(L10n.tr(
                                "settings.general.cliproxy.url.subtitle",
                                fallback: "Global default for providers using API source (for example Codex)."))
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                            TextField(
                                L10n.tr(
                                    "settings.general.cliproxy.url.placeholder",
                                    fallback: "http://127.0.0.1:8317"),
                                text: self.$settings.cliProxyGlobalBaseURL)
                                .textFieldStyle(.roundedBorder)
                                .font(.footnote)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.tr("settings.general.cliproxy.key.title", fallback: "Management Key"))
                                .font(.body)
                            SecureField(
                                L10n.tr(
                                    "settings.general.cliproxy.key.placeholder",
                                    fallback: "Paste management key…"),
                                text: self.$settings.cliProxyGlobalManagementKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.footnote)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.tr("settings.general.cliproxy.auth_index.title", fallback: "auth_index (optional)"))
                                .font(.body)
                            Text(L10n.tr(
                                "settings.general.cliproxy.auth_index.subtitle",
                                fallback: "Optional. Set a specific auth file; leave empty to aggregate all Codex auth entries."))
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                            TextField(
                                L10n.tr(
                                    "settings.general.cliproxy.auth_index.placeholder",
                                    fallback: "Leave empty to load all available Codex auth entries"),
                                text: self.$settings.cliProxyGlobalAuthIndex)
                                .textFieldStyle(.roundedBorder)
                                .font(.footnote)
                        }
                    }
                }

                Divider()

                SettingsSection(contentSpacing: 12) {
                    Text(L10n.tr("settings.general.usage.section", fallback: "Usage"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(isOn: self.$settings.costUsageEnabled) {
                                Text(L10n.tr("settings.general.usage.cost_summary.title", fallback: "Show cost summary"))
                                    .font(.body)
                            }
                            .toggleStyle(.checkbox)

                            Text(L10n.tr(
                                "settings.general.usage.cost_summary.subtitle",
                                fallback: "Reads local usage logs. Shows today + last 30 days cost in the menu."))
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)

                            if self.settings.costUsageEnabled {
                                Text(L10n.tr(
                                    "settings.general.usage.cost_summary.refresh_hint",
                                    fallback: "Auto-refresh: hourly · Timeout: 10m"))
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
                    Text(L10n.tr("settings.general.automation.section", fallback: "Automation"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.tr("settings.general.automation.refresh_cadence.title", fallback: "Refresh cadence"))
                                    .font(.body)
                                Text(L10n.tr(
                                    "settings.general.automation.refresh_cadence.subtitle",
                                    fallback: "How often CodexBar polls providers in the background."))
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Picker(
                                L10n.tr("settings.general.automation.refresh_cadence.title", fallback: "Refresh cadence"),
                                selection: self.$settings.refreshFrequency)
                            {
                                ForEach(RefreshFrequency.allCases) { option in
                                    Text(option.label).tag(option)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: 200)
                        }
                        if self.settings.refreshFrequency == .manual {
                            Text(L10n.tr(
                                "settings.general.automation.refresh_cadence.manual_hint",
                                fallback: "Auto-refresh is off; use the menu's Refresh command."))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    PreferenceToggleRow(
                        title: L10n.tr("settings.general.automation.check_status.title", fallback: "Check provider status"),
                        subtitle: L10n.tr(
                            "settings.general.automation.check_status.subtitle",
                            fallback: "Polls OpenAI/Claude status pages and Google Workspace for Gemini/Antigravity, surfacing incidents in the icon and menu."),
                        binding: self.$settings.statusChecksEnabled)
                    PreferenceToggleRow(
                        title: L10n.tr(
                            "settings.general.automation.session_quota.title",
                            fallback: "Session quota notifications"),
                        subtitle: L10n.tr(
                            "settings.general.automation.session_quota.subtitle",
                            fallback: "Notifies when the 5-hour session quota hits 0% and when it becomes available again."),
                        binding: self.$settings.sessionQuotaNotificationsEnabled)
                }

                Divider()

                SettingsSection(contentSpacing: 12) {
                    HStack {
                        Spacer()
                        Button(L10n.tr("settings.general.quit", fallback: "Quit CodexBar")) { NSApp.terminate(nil) }
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
            let format = L10n.tr("settings.general.usage.cost_status.unsupported", fallback: "%@: unsupported")
            return Text(String(format: format, locale: .current, name))
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
            let format = L10n.tr("settings.general.usage.cost_status.fetching", fallback: "%@: fetching…%@")
            return Text(String(format: format, locale: .current, name, elapsed))
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        if let snapshot = self.store.tokenSnapshot(for: provider) {
            let updated = UsageFormatter.updatedString(from: snapshot.updatedAt)
            let cost = snapshot.last30DaysCostUSD.map { UsageFormatter.usdString($0) } ?? "—"
            let format = L10n.tr("settings.general.usage.cost_status.snapshot", fallback: "%@: %@ · 30d %@")
            return Text(String(format: format, locale: .current, name, updated, cost))
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        if let error = self.store.tokenError(for: provider), !error.isEmpty {
            let truncated = UsageFormatter.truncatedSingleLine(error, max: 120)
            return Text("\(name): \(truncated)")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        if let lastAttempt = self.store.tokenLastAttemptAt(for: provider) {
            let rel = RelativeDateTimeFormatter()
            rel.unitsStyle = .abbreviated
            let when = rel.localizedString(for: lastAttempt, relativeTo: Date())
            let format = L10n.tr("settings.general.usage.cost_status.last_attempt", fallback: "%@: last attempt %@")
            return Text(String(format: format, locale: .current, name, when))
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        let format = L10n.tr("settings.general.usage.cost_status.no_data", fallback: "%@: no data yet")
        return Text(String(format: format, locale: .current, name))
            .font(.footnote)
            .foregroundStyle(.tertiary)
    }

    private func restartApp() {
        let bundleURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
    }
}
