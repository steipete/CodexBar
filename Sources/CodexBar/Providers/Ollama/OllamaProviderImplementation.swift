import CodexBarCore
import Foundation

struct OllamaProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .ollama

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.ollamaUsageDataSource
        _ = settings.ollamaAPIToken
        _ = settings.ollamaCookieSource
        _ = settings.ollamaCookieHeader
    }

    @MainActor
    func sourceMode(context: ProviderSourceModeContext) -> ProviderSourceMode {
        context.settings.ollamaUsageDataSource
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if OllamaAPISettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        if !context.settings.ollamaAPIToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return context.settings.ollamaCookieSource != .off
    }

    @MainActor
    func tokenAccountsVisibility(context: ProviderSettingsContext, support: TokenAccountSupport) -> Bool {
        guard support.requiresManualCookieSource else { return true }
        if !context.settings.tokenAccounts(for: context.provider).isEmpty { return true }
        return context.settings.ollamaCookieSource == .manual
    }

    @MainActor
    func applyTokenAccountCookieSource(settings: SettingsStore) {
        if settings.ollamaCookieSource != .manual {
            settings.ollamaCookieSource = .manual
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let sourceBinding = context.rawValueBinding(\.ollamaUsageDataSource, fallback: .auto)
        let sourceOptions: [ProviderSettingsPickerOption] = [
            ProviderSettingsPickerOption(id: ProviderSourceMode.auto.rawValue, title: "Auto"),
            ProviderSettingsPickerOption(id: ProviderSourceMode.web.rawValue, title: "Browser cookies"),
            ProviderSettingsPickerOption(id: ProviderSourceMode.api.rawValue, title: "API key"),
        ]
        return [
            ProviderSettingsPickerDescriptor(
                id: "ollama-usage-source",
                title: "Usage source",
                subtitle: "API key verifies Ollama Cloud access; cookies still expose quota limits.",
                binding: sourceBinding,
                options: sourceOptions,
                isVisible: nil,
                onChange: nil),
            ProviderCookieSourceUI.picker(
                id: "ollama-cookie-source",
                context: context,
                source: \.ollamaCookieSource,
                allowsOff: false,
                subtitles: {
                    .init(
                        auto: L("Automatic imports browser cookies."),
                        manual: L("Paste a Cookie header or cURL capture from %@.", "Ollama settings"),
                        off: L("%@ cookies are disabled.", "Ollama"))
                },
                trailingText: {
                    guard context.settings.ollamaUsageDataSource != .api else { return nil }
                    return ProviderCookieRefreshAction.trailingText(
                        provider: .ollama,
                        cookieSource: context.settings.ollamaCookieSource,
                        context: context)
                },
                trailingActions: [
                    ProviderCookieRefreshAction.descriptor(
                        provider: .ollama,
                        cookieSource: { context.settings.ollamaCookieSource },
                        additionalVisibility: { context.settings.ollamaUsageDataSource != .api },
                        context: context),
                ]),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "ollama-api-key",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. Get your key from Ollama settings.",
                kind: .secure,
                placeholder: "ollama-...",
                binding: context.binding(\.ollamaAPIToken),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "ollama-open-api-keys",
                        title: "Open Ollama API Keys",
                        url: URL(string: "https://ollama.com/settings/keys")),
                ],
                isVisible: nil),
            ProviderSettingsFieldDescriptor(
                id: "ollama-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: …",
                binding: context.binding(\.ollamaCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "ollama-open-settings",
                        title: "Open Ollama Settings",
                        url: URL(string: "https://ollama.com/settings")),
                ],
                isVisible: { context.settings.ollamaCookieSource == .manual }),
        ]
    }
}
