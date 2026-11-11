import CodexBarCore
import Foundation
import SwiftUI

struct ClaudePlatformAWSProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .claudeplatformaws

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        // Access key ID, then its secret, then the regions field supplied by the shared spec.
        var fields = PluginAPIKeyProviderImplementation(spec: ClaudePlatformAWSProviderDescriptor.spec)
            .settingsFields(context: context)
        fields.insert(
            ProviderSettingsFieldDescriptor(
                id: "claudeplatformaws-secret-access-key",
                title: "Secret access key",
                subtitle: "Required with the access key ID. Saved in the local config file. "
                    + "Or set ANTHROPIC_AWS_SECRET_ACCESS_KEY.",
                kind: .secure,
                placeholder: "Paste secret key…",
                binding: context.providerConfigSecretBinding(
                    key: ClaudePlatformAWSProviderDescriptor.secretAccessKeyEnvironmentKey,
                    logField: "secretAccessKey"),
                actions: [],
                isVisible: nil),
            at: min(1, fields.count))
        fields.append(self.pluginSettingField(
            id: "claudeplatformaws-monthly-budget",
            title: "Monthly budget",
            subtitle: "Optional, in USD. Compares this month's spend with the amount; it does not cap AWS billing. "
                + "Or set ANTHROPIC_AWS_MONTHLY_BUDGET.",
            key: ClaudePlatformAWSProviderDescriptor.monthlyBudgetEnvironmentKey,
            context: context))
        fields.append(self.pluginSettingField(
            id: "claudeplatformaws-daily-budget",
            title: "Daily budget",
            subtitle: "Optional, in USD. Compares today's spend with the amount. "
                + "Or set ANTHROPIC_AWS_DAILY_BUDGET.",
            key: ClaudePlatformAWSProviderDescriptor.dailyBudgetEnvironmentKey,
            context: context))
        fields.append(self.pluginSettingField(
            id: "claudeplatformaws-time-zone",
            title: "Time zone",
            subtitle: "Where days and months begin: local (default, this Mac's time zone) or utc. "
                + "Or set ANTHROPIC_AWS_TIME_ZONE.",
            placeholder: "local",
            key: ClaudePlatformAWSProviderDescriptor.timeZoneEnvironmentKey,
            context: context))
        return fields
    }

    @MainActor
    private func pluginSettingField(
        id: String,
        title: String,
        subtitle: String,
        placeholder: String? = nil,
        key: String,
        context: ProviderSettingsContext) -> ProviderSettingsFieldDescriptor
    {
        ProviderSettingsFieldDescriptor(
            id: id,
            title: title,
            subtitle: subtitle,
            kind: .plain,
            placeholder: placeholder,
            binding: Binding(
                get: { context.settings.providerConfig(for: self.id)?.pluginSettings?[key] ?? "" },
                set: { value in
                    context.settings.updateProviderConfig(provider: self.id) { config in
                        var values = config.pluginSettings ?? [:]
                        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        values[key] = cleaned.isEmpty ? nil : cleaned
                        config.pluginSettings = values.isEmpty ? nil : values
                    }
                }),
            actions: [],
            isVisible: nil)
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.providerConfig(for: self.id)
    }
}
