import CodexBarCore

struct ClineProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .cline

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings[providerConfig: .cline, field: .apiKey]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [ProviderSettingsFieldDescriptor(
            id: "cline-api-key",
            title: "Cline API key",
            subtitle: "Saved in CodexBar's local config file. Or set CLINE_API_KEY. " +
                "Run `cline auth` to sign in with your browser instead (reads ~/.cline/data/settings/providers.json).",
            kind: .secure,
            placeholder: "Paste API key…",
            binding: context.providerConfigBinding(.apiKey),
            actions: [],
            isVisible: nil)]
    }
}
