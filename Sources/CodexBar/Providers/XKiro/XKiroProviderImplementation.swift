import CodexBarCore

struct XKiroProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .xkiro

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings[providerConfig: .xkiro, field: .apiKey]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [ProviderSettingsFieldDescriptor(
            id: "xkiro-api-key",
            title: "xKiro API key",
            subtitle: "Saved in CodexBar's local config file. Or set XKIRO_API_KEY. Reads free-token usage only.",
            kind: .secure,
            placeholder: "Paste API key…",
            binding: context.providerConfigBinding(.apiKey),
            actions: [],
            isVisible: nil)]
    }
}
