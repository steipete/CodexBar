import CodexBarCore
import Foundation

struct GitKrakenProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .gitkraken

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.gitkrakenUsageDataSource
        _ = settings.gitkrakenAPIToken
        _ = settings.gitkrakenOrganizationID
    }

    @MainActor
    func sourceMode(context: ProviderSourceModeContext) -> ProviderSourceMode {
        context.settings.gitkrakenUsageDataSource
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        [
            ProviderSettingsPickerDescriptor(
                id: "gitkraken-usage-source",
                title: "Usage source",
                subtitle: "Auto tries the API, then the signed-in gk CLI. " +
                    "For CLI access, run gk auth login in Terminal.",
                binding: context.rawValueBinding(\.gitkrakenUsageDataSource, fallback: .auto),
                options: [
                    .init(id: ProviderSourceMode.auto.rawValue, title: "Auto"),
                    .init(id: ProviderSourceMode.api.rawValue, title: "GitKraken API"),
                    .init(id: ProviderSourceMode.cli.rawValue, title: "GitKraken CLI"),
                ],
                isVisible: nil,
                onChange: nil),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "gitkraken-api-token",
                title: "GitKraken access token",
                subtitle: "Optional GitKraken account access token. Saved in CodexBar's local config file, " +
                    "not Keychain. Or set GITKRAKEN_API_TOKEN.",
                kind: .secure,
                placeholder: "Token value only (without Bearer)",
                binding: context.binding(\.gitkrakenAPIToken),
                actions: [
                    .openURL(
                        id: "gitkraken-open-account",
                        title: "Open GitKraken Account",
                        url: URL(string: "https://gitkraken.dev/account#ai-usage")),
                ],
                isVisible: { context.settings.gitkrakenUsageDataSource != .cli }),
            ProviderSettingsFieldDescriptor(
                id: "gitkraken-organization",
                title: "API organization ID",
                subtitle: "Optional gk-org-id header value. Pinning an organization disables Auto's CLI fallback " +
                    "so it cannot switch to another organization's allowance.",
                kind: .plain,
                placeholder: "Organization ID (optional)",
                binding: context.binding(\.gitkrakenOrganizationID),
                actions: [],
                isVisible: { context.settings.gitkrakenUsageDataSource != .cli }),
        ]
    }
}

extension SettingsStore {
    var gitkrakenUsageDataSource: ProviderSourceMode {
        get { self.configSnapshot.providerConfig(for: .gitkraken)?.source ?? .auto }
        set {
            self.updateProviderConfig(provider: .gitkraken) { entry in
                entry.source = newValue == .auto ? nil : newValue
            }
            self.logProviderModeChange(provider: .gitkraken, field: "source", value: newValue.rawValue)
        }
    }

    var gitkrakenAPIToken: String {
        get { self[providerConfig: .gitkraken, field: .apiKey] }
        set { self[providerConfig: .gitkraken, field: .apiKey] = newValue }
    }

    /// Reuse the generic scope field; no provider-specific config-schema changes are needed.
    var gitkrakenOrganizationID: String {
        get { self.configSnapshot.providerConfig(for: .gitkraken)?.sanitizedWorkspaceID ?? "" }
        set {
            self.updateProviderConfig(provider: .gitkraken) { entry in
                entry.workspaceID = self.normalizedConfigValue(newValue)
            }
        }
    }
}
